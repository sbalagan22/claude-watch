import AppKit
import ApplicationServices
import Foundation

/// Clicking a row lands on that session — the tab or window it is running
/// in, not merely the application.
///
/// The hook records whatever handle the terminal exposes (`FocusHints`), and
/// this walks the tiers from most to least precise:
///
///  1. **Exact tab.** iTerm2 selects a session by unique id; Terminal.app
///     selects the tab that owns the session's tty; kitty and WezTerm take
///     their window/pane id over their own CLIs. Each needs only Automation
///     permission, which macOS asks for on first use.
///  2. **Exact window by title.** IDEs (VS Code and its forks, including
///     Antigravity and Cursor) have no per-window scripting, but every window
///     title carries the workspace folder. With Accessibility permission the
///     window whose title contains the project name is raised. Same fallback
///     for Ghostty, Warp and other terminals that put the cwd in the title.
///  3. **The right app.** By the spawning app's bundle id (recorded from
///     `__CFBundleIdentifier`, which survives even when TERM_PROGRAM is empty),
///     then by walking up from the owning PID, then by the terminal label.
///  4. **The folder in Finder**, which always works.
@MainActor
enum SessionFocuser {
    static func focus(_ session: Session) {
        if focusExactTab(session) { return }
        if let app = hostApplication(for: session) {
            if raiseWindow(of: app, matching: session) { return }
            _ = app.activate(options: [.activateAllWindows])
            return
        }
        if activateByEnvironment(session.environment) { return }
        revealInFinder(session.cwd)
    }

    // MARK: - Tier 1: exact tab

    private static func focusExactTab(_ session: Session) -> Bool {
        let h = session.focus
        if !h.itermUniqueID.isEmpty, isRunning("com.googlecode.iterm2") {
            return runAppleScript("""
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if unique id of s is "\(h.itermUniqueID)" then
                                select t
                                select s
                                set index of w to 1
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """)
        }
        if !h.tty.isEmpty, isRunning("com.apple.Terminal") {
            return runAppleScript("""
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "/dev/\(h.tty)" then
                            set selected tab of w to t
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """)
        }
        if !h.kittyWindowID.isEmpty,
           let kitten = executable(inApp: "net.kovidgoyal.kitty", named: "kitten") {
            return run(kitten, ["@", "focus-window", "--match", "id:\(h.kittyWindowID)"])
                && activate("net.kovidgoyal.kitty")
        }
        if !h.weztermPane.isEmpty,
           let wezterm = executable(inApp: "com.github.wez.wezterm", named: "wezterm") {
            return run(wezterm, ["cli", "activate-pane", "--pane-id", h.weztermPane])
                && activate("com.github.wez.wezterm")
        }
        return false
    }

    // MARK: - Tier 2: exact window

    /// Raise the window whose title names the project. Needs Accessibility;
    /// the system prompt is shown once, then this degrades to app activation
    /// until the user grants it.
    private static func raiseWindow(of app: NSRunningApplication, matching session: Session) -> Bool {
        guard ensureAccessibility() else { return false }
        let needles = [session.projectName, (session.cwd as NSString).lastPathComponent]
            .filter { !$0.isEmpty }
        guard !needles.isEmpty else { return false }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }

        for window in windows {
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                  let title = titleValue as? String else { continue }
            if needles.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                return app.activate(options: [])
            }
        }
        return false
    }

    private static func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        // Ask once. A second click on a row before the user has decided must
        // not stack dialogs.
        if !Preferences.shared.hasRequestedAccessibility {
            Preferences.shared.hasRequestedAccessibility = true
            // The framework constant is a global var Swift 6 will not let a
            // main-actor context touch; its value is this fixed string.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        return false
    }

    // MARK: - Tier 3: the app

    private static func hostApplication(for session: Session) -> NSRunningApplication? {
        if session.focus.hostPID > 0,
           let app = NSRunningApplication(processIdentifier: session.focus.hostPID),
           app.activationPolicy == .regular {
            return app
        }
        if !session.focus.hostBundleID.isEmpty,
           let app = NSRunningApplication
               .runningApplications(withBundleIdentifier: session.focus.hostBundleID).first {
            return app
        }
        return windowOwner(from: session.ownerPID)
    }

    /// Walk up from the recorded PID to the nearest process that owns windows.
    private static func windowOwner(from pid: pid_t) -> NSRunningApplication? {
        guard pid > 0 else { return nil }
        var current = pid
        for _ in 0..<6 {
            if let app = NSRunningApplication(processIdentifier: current),
               app.activationPolicy == .regular {
                return app
            }
            guard let parent = parentPID(of: current), parent > 1 else { break }
            current = parent
        }
        return nil
    }

    /// The parent of a process, via sysctl. Cheaper and more reliable than
    /// shelling out to `ps`.
    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { buf -> Int32 in
            sysctl(buf.baseAddress, u_int(buf.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    private static func activateByEnvironment(_ env: Environment) -> Bool {
        let candidates: [String] = switch env.label {
        case "VS Code":  ["com.microsoft.VSCode", "com.visualstudio.code.oss"]
        case "Cursor":   ["com.todesktop.230313mzl4w4u92"]
        case "Windsurf": ["com.exafunction.windsurf"]
        case "Terminal": ["com.apple.Terminal"]
        case "iTerm":    ["com.googlecode.iterm2"]
        case "Ghostty":  ["com.mitchellh.ghostty"]
        case "Warp":     ["dev.warp.Warp-Stable"]
        case "Hyper":    ["co.zeit.hyper"]
        case "kitty":    ["net.kovidgoyal.kitty"]
        case "WezTerm":  ["com.github.wez.wezterm"]
        case "Alacritty":["org.alacritty"]
        default: []
        }
        return candidates.contains(where: activate)
    }

    // MARK: - Tier 4

    private static func revealInFinder(_ path: String) {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Helpers

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static func activate(_ bundleID: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return false }
        return app.activate(options: [.activateAllWindows])
    }

    /// Runs a script that returns a boolean. Any error — including a denied
    /// Automation permission — reads as false so the next tier runs.
    private static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&error)
        return error == nil && result.booleanValue
    }

    private static func executable(inApp bundleID: String, named name: String) -> URL? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let url = appURL.appending(path: "Contents/MacOS/\(name)")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private static func run(_ executable: URL, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = nil
        process.standardError = nil
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
